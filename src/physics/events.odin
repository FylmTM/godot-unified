// The step's events (src/physics/README.md, Results): contacts, sensors, joints and body moves, in Box3D's
// order (part of the world state, so the same after a restore and on every machine). Read them in the tick that
// stepped, before destroying bodies; a re-simulation regenerates them, and nothing about them is kept.
package physics

import box3d "box3d:bindings"

// A contact between two shapes: touching began or ended (both shapes with contact events on), or a hit (one with
// hit events on, approaching faster than Settings.hit_event_threshold).
Contact_Event :: struct {
	kind:   Contact_Kind,
	a, b:   Overlap, // an End's shape may be gone (destroyed this step): zero
	point:  [3]f32, // .Hit only
	normal: [3]f32, // .Hit only: from a to b
	speed:  f32, // .Hit only: the approach speed
}

// What a contact event reports: touching began, touching ended, or a hit.
Contact_Kind :: enum u8 {
	Begin,
	End,
	Hit,
}

// A shape entered or left a sensor (the visitor's shape has sensor events on: Shape_Def.enable_sensor_events).
Sensor_Event :: struct {
	kind:    Sensor_Kind,
	sensor:  Overlap,
	visitor: Overlap, // an End's visitor may be gone: zero
}

// What a sensor event reports: the visitor entered or left the sensor.
Sensor_Kind :: enum u8 {
	Begin,
	End,
}

// A body that moved in the last step (every awake dynamic or kinematic body).
Body_Move_Event :: struct {
	body:        Body_Link,
	tag:         u64,
	transform:   Transform,
	fell_asleep: bool,
}

// The step's contact events into `out` (replaced): the begins, the ends, then the hits, each in Box3D's order.
world_contact_events :: proc(world: ^World, out: ^[dynamic]Contact_Event) {
	clear(out)
	events := box3d.World_GetContactEvents(world.id)
	for event in events.beginEvents[:events.beginCount] {
		append(
			out,
			Contact_Event{kind = .Begin, a = overlap_of(world, event.shapeIdA), b = overlap_of(world, event.shapeIdB)},
		)
	}
	for event in events.endEvents[:events.endCount] {
		append(
			out,
			Contact_Event{kind = .End, a = overlap_of(world, event.shapeIdA), b = overlap_of(world, event.shapeIdB)},
		)
	}
	for event in events.hitEvents[:events.hitCount] {
		append(out, Contact_Event {
			kind   = .Hit,
			a      = overlap_of(world, event.shapeIdA),
			b      = overlap_of(world, event.shapeIdB),
			point  = transmute([3]f32)event.point,
			normal = transmute([3]f32)event.normal,
			speed  = event.approachSpeed,
		})
	}
}

// The step's sensor events into `out` (replaced): the begins, then the ends, each in Box3D's order (sorted by
// unified-box3d: the same on every platform).
world_sensor_events :: proc(world: ^World, out: ^[dynamic]Sensor_Event) {
	clear(out)
	events := box3d.World_GetSensorEvents(world.id)
	for event in events.beginEvents[:events.beginCount] {
		append(
			out,
			Sensor_Event{.Begin, overlap_of(world, event.sensorShapeId), overlap_of(world, event.visitorShapeId)},
		)
	}
	for event in events.endEvents[:events.endCount] {
		append(
			out,
			Sensor_Event{.End, overlap_of(world, event.sensorShapeId), overlap_of(world, event.visitorShapeId)},
		)
	}
}

// The joints whose force or torque passed their threshold in the last step, into `out` (replaced), in Box3D's order
// (joint_as gives a typed ref).
world_joint_events :: proc(world: ^World, out: ^[dynamic]Joint_Ref) {
	clear(out)
	events := box3d.World_GetJointEvents(world.id)
	for event in events.jointEvents[:events.count] {
		append(out, joint_ref_of(event.jointId))
	}
}

// The bodies that moved in the last step, into `out` (replaced), in Box3D's order: every awake dynamic or kinematic
// body, `fell_asleep` on the step it fell asleep.
world_body_events :: proc(world: ^World, out: ^[dynamic]Body_Move_Event) {
	clear(out)
	events := box3d.World_GetBodyEvents(world.id)
	for event in events.moveEvents[:events.moveCount] {
		append(out, Body_Move_Event {
			body        = link_of(event.bodyId),
			tag         = tag_of(world, event.bodyId.index1),
			transform   = transmute(Transform)event.transform,
			fell_asleep = event.fellAsleep,
		})
	}
}
