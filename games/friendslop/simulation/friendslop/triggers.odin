package friendslop

import "unified:physics"
import "unified:sim"

// The triggers after the step, from their sensors: a pressure plate is pressed while the mass in it reaches its
// threshold, and a switch (a player in it) or a lock (the key in it) latches on. Bells ring on hits (apply_hits); their
// cooldown runs out here.
press_triggers :: proc(t: ^Tick) {
	for i in 0 ..< t.world.trigger_count {
		def := &t.world.triggers[i]
		trigger := &t.state.triggers[i]
		if trigger.cooldown > 0 do trigger.cooldown -= 1
		entity, position := sim.entity(def.marker), sim.Position(def.volume.pos)
		switch def.kind {
		case .Plate:
			mass := sensor_mass(t.world, def.sensor)
			pressed := mass >= def.mass
			if pressed == trigger.active do continue
			trigger.active = pressed
			if pressed {
				sim.emit(t, Event_Plate_On{entity = entity, position = position, mass = mass})
			} else {
				sim.emit(t, Event_Plate_Off{entity = entity, position = position, mass = mass})
			}
		case .Switch:
			if trigger.active do continue
			physics.shape_sensor_data(t.world.phys, def.sensor, &t.world.overlaps)
			for visitor in t.world.overlaps {
				player := sim.player_of_key(visitor.tag)
				character := sim.player_data(t, player)
				if character == nil || character.respawn > 0 || !sim.player_present(t, player) do continue
				trigger.active = true
				sim.emit(t, Event_Switch_On{entity = entity, position = position, player = player})
				break
			}
		case .Lock:
			if trigger.active do continue
			physics.shape_sensor_data(t.world.phys, def.sensor, &t.world.overlaps)
			for visitor in t.world.overlaps {
				index := int(visitor.tag)
				if t.world.items[index].kind != .Key || !t.state.items[index].alive do continue
				trigger.active = true
				sim.emit(t, Event_Switch_On{entity = entity, position = position})
				break
			}
		case .Bell:
		}
	}
}

// The mass of the bodies in a sensor (each body once, however many of its shapes are in it).
sensor_mass :: proc(world: ^World, sensor: physics.Shape_Ref) -> (mass: f32) {
	physics.shape_sensor_data(world.phys, sensor, &world.overlaps)
	last := physics.Body_Link{}
	for visitor in world.overlaps {
		if visitor.body == last do continue
		last = visitor.body
		body := physics.resolve(world.phys, visitor.body) or_continue
		mass += physics.body_mass(world.phys, body)
	}
	return
}
