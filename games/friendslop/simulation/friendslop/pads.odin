package friendslop

import "unified:physics"
import "unified:sim"

// Launches players whose feet and items whose bottom are inside a jump pad's volume, with a per-body cooldown. The
// sim checks the volumes itself rather than using Box3D sensors.
launch_from_pads :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.pad_cooldown > 0 do character.pad_cooldown -= 1
		if character.respawn > 0 || character.held_by != {} || character.pad_cooldown > 0 do continue
		feet := player_pos(t, player) - {0, FEET - PAD_PROBE_UP, 0}
		for &pad in t.world.pads[:t.world.pad_count] {
			if !in_volume(pad.volume, feet) do continue
			launch(t.world, &pad, character.controller.body)
			physics.character_launch(t.world.phys, &character.controller)
			character.pad_cooldown = PAD_COOLDOWN_TICKS
			sim.emit(t, Event_Launched{position = sim.Position(pad.volume.pos), player = player})
			break
		}
	}
	for i in 0 ..< t.world.item_count {
		item := &t.state.items[i]
		if item.pad_cooldown > 0 do item.pad_cooldown -= 1
		if item.holders != {} || item.pad_cooldown > 0 do continue
		bottom :=
			physics.body_position(t.world.phys, item.body) -
			{0, ITEM_SPECS[t.world.items[i].kind].radius * PAD_ITEM_PROBE, 0}
		for &pad in t.world.pads[:t.world.pad_count] {
			if !in_volume(pad.volume, bottom) do continue
			launch(t.world, &pad, item.body)
			item.pad_cooldown = PAD_COOLDOWN_TICKS
			sim.emit(
				t,
				Event_Launched{entity = sim.entity(t.world.items[i].marker), position = sim.Position(pad.volume.pos)},
			)
			break
		}
	}
}

// A pad's launch: its vertical speed; a directed pad (a horizontal push) also sets the horizontal velocity, so it
// lands where the level expects whatever the run-up; a straight-up pad keeps it.
launch :: proc(world: ^World, pad: ^Pad_Def, body: physics.Body_Ref) {
	velocity := pad.launch
	if pad.launch.x == 0 && pad.launch.z == 0 {
		velocity = physics.body_linear_velocity(world.phys, body)
		velocity.y = pad.launch.y
	}
	physics.body_set_linear_velocity(world.phys, body, velocity)
}
