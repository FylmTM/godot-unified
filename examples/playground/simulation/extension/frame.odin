// The view contract (examples/playground/README.md, View contract) and the frame: every body drawn from the shape the
// sim made it with, as a MultiMesh instance per shape kind, the cameras and sensors as scene views, the HUD's data.
package playground_extension

import "core:math"

import "unified:dmath"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../playground"

Frame :: godot.Frame(g.Game, View, MultiView)

// The scene views, a struct per kind: its views' data.
View :: union {
	View_Camera, // a player's flying camera (keyed by its player)
	View_Sensor, // a sensor volume of the Sensors scene (keyed by its index)
}

MultiView :: enum u8 {
	Box, // a unit cube, scaled to the box
	Sphere, // a unit-diameter sphere, scaled
	Capsule, // a unit sphere the capsule shader stretches: custom.x the radius, custom.y the segment's half length
	Cylinder, // a unit cylinder (diameter and height 1), scaled
}

// A camera: its player's colour, and what they are doing.
View_Camera :: struct {
	color:   godot.Color,
	holding: bool,
	driving: bool,
	local:   bool, // the local player's own camera (its view hides itself)
	_pad:    u8,
	grab_at: sim.Position, // where the grab pulls to (holding)
}

// A sensor: its half extents and how many bodies are in it.
View_Sensor :: struct {
	half:   [3]f32,
	inside: u32,
	visits: u32,
}

Data :: union {
	Data_Hud,
}

// The HUD: the scene, who plays, how many bodies the scene holds and what the local player is doing.
Data_Hud :: struct {
	scene:   g.Scene, // EnumScene
	driving: bool, // the local player drives a car
	holding: bool,
	_pad:    u8,
	players: u32,
	props:   u32, // bodies in the block's table
	bodies:  u32, // every body of the scene (props, ragdoll bones, car parts)
	awake:   u32, // physics.world_awake_body_count
	color:   godot.Color, // the local player's
}

PLAYER_COLORS := [g.PLAYERS]godot.Color{{1, 0.45, 0.4, 1}, {0.55, 0.9, 0.4, 1}, {0.4, 0.8, 1, 1}, {0.85, 0.55, 1, 1}}

// A body's colour by what it is: a scene's by its shape, a spawn and a bullet by their player's colour.
ROLE_COLORS := [g.Role]godot.Color {
	.Scene   = {0.86, 0.66, 0.42, 1},
	.Spawned = {1, 1, 1, 1}, // tinted by its owner
	.Bullet  = {1, 0.9, 0.3, 1},
	.Rain    = {0.55, 0.7, 0.95, 1},
	.Anchor  = {0.4, 0.4, 0.45, 1},
}

// Keys of the instances that are no prop (a prop's is its handle's key), per kind: far above any handle key.
RAGDOLL_KEY :: u64(1) << 60
CAR_KEY :: u64(2) << 60

fill_frame :: proc(f: ^Frame) {
	fill_frame_cameras(f)
	fill_frame_props(f)
	fill_frame_ragdolls(f)
	fill_frame_cars(f)
	fill_frame_sensors(f)
	fill_frame_hud(f)
}

fill_frame_cameras :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for data, player in sim.next(&players) {
		slot, _ := sim.player_slot(&f.state.players, player)
		look := dmath.aim_vec(data.aim)
		godot.push_view(
			f,
			player,
			{pos = sim.Position(data.pos), rot = dmath.aim_quat(data.aim), warp = data.warp},
			View_Camera {
				color   = PLAYER_COLORS[slot],
				holding = data.grab != {},
				driving = data.car >= 0,
				local   = godot.is_local(f, player),
				grab_at = sim.Position(data.pos + look * data.grab_dist),
			},
		)
	}
}

fill_frame_props :: proc(f: ^Frame) {
	world := f.world.phys
	props := sim.iterate(&f.state.props)
	for prop, handle in sim.next(&props) {
		color := ROLE_COLORS[prop.role]
		if prop.role == .Spawned || (prop.role == .Bullet && prop.owner != {}) {
			if slot, present := sim.player_slot(&f.state.players, prop.owner); present do color = PLAYER_COLORS[slot]
		}
		if prop.role == .Scene && prop.kind == .Sphere do color = {0.95, 0.55, 0.35, 1}
		if sim.timer_running_at(f.time, prop.flash) do color = {1, 1, 0.6, 1}
		if prop.inside > 0 do color = {0.4, 1, 0.6, 1}
		if !physics.body_is_awake(world, prop.body) do color.rgb *= 0.8
		transform := physics.body_transform(world, prop.body)
		item := godot.Multi_View_Item(MultiView) {
			key   = sim.handle_key(handle),
			pos   = sim.Position(transform.p),
			rot   = transform.q,
			color = color,
		}
		switch prop.kind {
		case .Box:
			item.kind, item.scale = .Box, prop.size * 2
		case .Sphere:
			item.kind, item.scale = .Sphere, prop.size.x * 2
		case .Cylinder:
			item.kind, item.scale = .Cylinder, {prop.size.x * 2, prop.size.y * 2, prop.size.x * 2}
		case .Capsule:
			item.kind, item.custom = .Capsule, {prop.size.x, prop.size.y, 0, 0}
		}
		godot.push_multi_view(f, item)
	}
}

// Every ragdoll bone's capsules (physics.ragdoll_capsules) at the bone's body: segment centre, turned so the capsule
// shader's y runs along the segment.
fill_frame_ragdolls :: proc(f: ^Frame) {
	world := f.world.phys
	for &ragdoll, r in f.state.ragdolls {
		if ragdoll.bones[.Pelvis] == {} do continue
		for bone in physics.Ragdoll_Bone {
			body := ragdoll.bones[bone]
			if !physics.body_valid(world, physics.link(body)) do continue
			transform := physics.body_transform(world, body)
			capsules, count := physics.ragdoll_capsules(bone, g.RAGDOLL_SCALE)
			for capsule, c in capsules[:count] {
				middle := (capsule.center1 + capsule.center2) / 2
				segment := capsule.center2 - capsule.center1
				half := dmath.length3(segment) / 2
				color :=
					bone == .Head || bone == .Left_Forearm || bone == .Right_Forearm ? godot.Color{0.95, 0.8, 0.65, 1} : godot.Color{0.35, 0.6, 0.85, 1}
				godot.push_multi_view(f, {
					key    = RAGDOLL_KEY + u64(r) * 32 + u64(bone) * 2 + u64(c),
					kind   = .Capsule,
					pos    = sim.Position(physics.body_world_point(world, body, middle)),
					rot    = dmath.quat_mul(transform.q, y_toward(segment)),
					color  = color,
					custom = {capsule.radius, half, 0, 0},
				})
			}
		}
	}
}

fill_frame_cars :: proc(f: ^Frame) {
	world := f.world.phys
	for &car, i in f.state.cars {
		if car.chassis == {} do continue
		color := godot.Color{0.9, 0.3, 0.3, 1}
		if car.driver != {} {
			if slot, present := sim.player_slot(&f.state.players, car.driver); present do color = PLAYER_COLORS[slot]
		}
		transform := physics.body_transform(world, car.chassis)
		godot.push_multi_view(f, {
			key   = CAR_KEY + u64(i) * 8,
			kind  = .Box,
			pos   = sim.Position(transform.p),
			rot   = transform.q,
			scale = g.CAR_HALF * 2,
			color = color,
		})
		for wheel, w in car.wheels {
			wheel_transform := physics.body_transform(world, wheel)
			godot.push_multi_view(
				f,
				{
					key   = CAR_KEY + u64(i) * 8 + 1 + u64(w),
					kind  = .Cylinder,
					pos   = sim.Position(wheel_transform.p),
					rot   = dmath.quat_mul(wheel_transform.q, g.Z_TO_Y), // the wheel spins about its z: the cylinder's y
					scale = {g.WHEEL_RADIUS * 2, 0.3, g.WHEEL_RADIUS * 2},
					color = {0.15, 0.15, 0.15, 1},
				},
			)
		}
	}
}

fill_frame_sensors :: proc(f: ^Frame) {
	if f.state.level.id != .Sensors do return
	for &sensor, i in f.state.sensors {
		if sensor.body == {} do continue
		godot.push_view(f, sim.entity(i), {pos = sim.Position(g.SENSOR_AT[i])}, View_Sensor {
			half   = g.SENSOR_HALF,
			inside = sensor.inside,
			visits = sensor.visits,
		})
	}
}

fill_frame_hud :: proc(f: ^Frame) {
	hud := Data_Hud {
		scene   = f.state.level.id,
		players = u32(sim.present_count(&f.state.players)),
		props   = u32(f.state.props.count),
		awake   = u32(physics.world_awake_body_count(f.world.phys)),
	}
	hud.bodies = hud.props
	for &ragdoll in f.state.ragdolls do hud.bodies += ragdoll.bones[.Pelvis] != {} ? len(physics.Ragdoll_Bone) : 0
	for &car in f.state.cars do hud.bodies += car.chassis != {} ? 5 : 0
	if slot, present := sim.player_slot(&f.state.players, f.local_players[0]); present {
		data := sim.player_data(&f.state.players, f.local_players[0])
		hud.color = PLAYER_COLORS[slot]
		hud.driving = data.car >= 0
		hud.holding = data.grab != {}
	}
	godot.push_data(f, hud)
}

// The rotation that turns +Y onto the direction of `segment` (the identity for a zero one).
y_toward :: proc(segment: [3]f32) -> [4]f32 {
	length := math.sqrt(segment.x * segment.x + segment.y * segment.y + segment.z * segment.z)
	if length == 0 do return {0, 0, 0, 1}
	d := segment / length
	if d.y < -0.9999 do return {1, 0, 0, 0} // a half turn about +X
	// the half-way quaternion: (y × d, 1 + y · d), normalized
	quat := [4]f32{d.z, 0, -d.x, 1 + d.y}
	return quat / math.sqrt(quat.x * quat.x + quat.z * quat.z + quat.w * quat.w)
}
