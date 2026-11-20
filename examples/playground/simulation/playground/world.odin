package playground

import "unified:physics"
import "unified:sim"

// Shape categories (filter bits): every query, contact and sensor reports the category of the shape it names, and a
// prop's tag is its handle's key.
CAT_STATIC :: u64(1 << 0) // the scenes' levels
CAT_PROP :: u64(1 << 1) // every body the block owns but the sensors
CAT_SENSOR :: u64(1 << 2) // the Sensors scene's volumes

// The tags of the bodies that are no prop: a car's and a ragdoll's (their index; a key of generation 0 names no live
// table item, sim.handle_of_key).
CAR_TAG :: u64(1000)
RAGDOLL_TAG :: u64(2000)

// The world outside the block: the physics world (every scene's level built once), the shared cylinder hull and
// per-tick scratch.
World :: struct {
	phys:     ^physics.World,
	cylinder: ^physics.Hull_Data, // radius 1, height 2, centred: a cylinder prop is it scaled
	hits:     [dynamic]physics.Hit, // scratch
	overlaps: [dynamic]physics.Overlap,
	contacts: [dynamic]physics.Contact_Event,
	sensed:   [dynamic]physics.Sensor_Event,
	joints:   [dynamic]physics.Joint_Ref,
}

// Builds the world from the scenes' levels (each scene's static ground, walls and slopes, src/level/README.md) and the
// cylinder hull the cylinder props scale. The bodies the block owns are made when a scene is entered (enter_scene).
world_create :: proc(seed: u64, levels: []sim.Level_File, _: Setup) -> ^World {
	world := new(World)
	problem: string
	world.phys, problem = physics.create_with_levels(
		{tick_hz = TICK_HZ, hit_event_threshold = HIT_SPEED},
		levels,
		CAT_STATIC,
	)
	assert(problem == "", problem)
	world.cylinder = physics.create_cylinder(2, 1, -1, 16)
	assert(world.cylinder != nil)
	return world
}

// Frees what world_create made.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	physics.destroy_hull(world.cylinder)
	delete(world.hits)
	delete(world.overlaps)
	delete(world.contacts)
	delete(world.sensed)
	delete(world.joints)
	free(world)
}

// The tick-0 state: the Setup's scene; players join into it when present.
init :: proc(t: ^Tick) {
	enter_scene(t, t.setup.scene, {})
}

// Takes everyone to `scene` (`player` asked; {}: the start): every grab lets go and every driver gets out, everything
// the old scene built goes (props, ragdolls, cars, sensors), the static level is swapped (physics.level_change), the
// new scene is built (build_scene) and every present player's camera goes to its start. Players stay: they are the
// block's.
enter_scene :: proc(t: ^Tick, scene: Scene, player: sim.Player) {
	world := t.world.phys
	players := sim.iterate_present(t)
	for data, someone in sim.next(&players) {
		release(t, someone)
		data.car = -1
	}
	physics.despawn_all(world, &t.state.props)
	for &ragdoll in t.state.ragdolls do physics.ragdoll_destroy(world, &ragdoll)
	for &car in t.state.cars do physics.destroy_refs(world, &car)
	for &sensor in t.state.sensors do physics.destroy_refs(world, &sensor)
	t.state.cars, t.state.sensors = {}, {}

	physics.level_change(t, world, scene)
	t.state.entered = t.time
	build_scene(t, scene)
	placed := sim.iterate_present(t)
	for data, someone in sim.next(&placed) {
		data.pos = camera_start(scene, sim.player_slot(t, someone))
		data.warp += 1
	}
	sim.emit(t, Event_Scene_Entered{player = player, scene = scene})
}

// The first Cmd_Scene of the tick (players in slot order) changes the scene.
change_scene :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			command := sent.(Cmd_Scene) or_continue
			enter_scene(t, command.scene, player)
			return
		}
	}
}

// Where a camera in `slot` starts in `scene`: behind the scene's front, side by side, looking at it from above.
camera_start :: proc(scene: Scene, slot: int) -> [3]f32 {
	distance: f32 = 18
	#partial switch scene {
	case .Bounce_House:
		distance = 3 // inside the room
	case .Driving:
		distance = 14
	case .Ragdolls:
		distance = 9
	case .Rain:
		distance = 16
	}
	height: f32 = scene == .Bounce_House ? 3 : scene == .Ragdolls ? 10 : 6
	return {f32(slot) * 2 - 3, height, distance}
}

// The present player who holds the grab on `body`, if any.
holder_of :: proc(t: ^Tick, body: physics.Body_Link) -> (holder: sim.Player, found: bool) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		if data.grab != {} && data.held_body == body do return player, true
	}
	return {}, false
}
