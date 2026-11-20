package playground

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Leaves (they let go and get out of their car) and arrivals (a camera at the scene's start for their slot). Whatever
// a player owns is keyed by their sim.Player, never the slot.
update_presence :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		release(t, player)
		leave_car(t, player)
		sim.player_data(t, player)^ = {
			car = -1,
		}
	}
	for player in t.player_changes.arrived {
		data := sim.player_data(t, player)
		data^ = {
			car = -1,
		}
		data.pos = camera_start(t.state.level.id, sim.player_slot(t, player))
	}
}

// Each present camera flies by its stick: forward along the look, right along the look's flat right, up along +Y, at
// up to FLY_SPEED, held inside the scene's box (FLY_BOUND, FLY_FLOOR, FLY_CEILING). A driver's camera rides behind
// their car instead (drive_cars steers it with the stick).
fly_cameras :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		input := sim.input(t, player)
		data.aim = input.aim
		if data.car >= 0 {
			car := &t.state.cars[data.car]
			if car.chassis != {} {
				world := t.world.phys
				behind := physics.body_world_vector(world, car.chassis, {-7, 0, 0})
				data.pos = physics.body_position(world, car.chassis) + {behind.x, 3, behind.z}
			}
			continue
		}
		forward := dmath.aim_vec(input.aim)
		_, right := dmath.aim_flat(input.aim)
		stick := [3]f32{f32(input.right), f32(input.up), f32(input.forward)} / 127
		move := right * stick.x + [3]f32{0, stick.y, 0} + forward * stick.z
		data.pos += dmath.clamp_length3(move, 1) * (FLY_SPEED * t.dt)
		data.pos.x = dmath.clamp(data.pos.x, -FLY_BOUND, FLY_BOUND)
		data.pos.z = dmath.clamp(data.pos.z, -FLY_BOUND, FLY_BOUND)
		data.pos.y = dmath.clamp(data.pos.y, FLY_FLOOR, FLY_CEILING)
	}
}
