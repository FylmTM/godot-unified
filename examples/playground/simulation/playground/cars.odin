package playground

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The quarter turns the Box3D sample builds its car with (b3ComputeQuatBetweenUnitVectors of axis pairs).
X_TO_Y :: [4]f32{0, 0, 0.70710678, 0.70710678} // about +Z
Z_TO_Y :: [4]f32{-0.70710678, 0, 0, 0.70710678} // about -X
Y_TO_Z :: [4]f32{0.70710678, 0, 0, 0.70710678} // about +X

CAR_HALF :: [3]f32{2, 0.5, 1} // the chassis box (its forward is +x)
WHEEL_RADIUS :: f32(0.4)
@(rodata)
WHEEL_AT := [4][3]f32{{1.5, -0.5, 0.8}, {1.5, -0.5, -0.8}, {-1.5, -0.5, 0.8}, {-1.5, -0.5, -0.8}} // in the chassis

// Where car `index` starts in the Driving scene.
car_start :: proc(index: int) -> [3]f32 {
	return {f32(index) * 6 - 9, 2.5, 0}
}

// Builds car `index` at its start, the sample's way: the chassis, a
// parallel joint to the World's anchor keeping it upright, and four sphere wheels on wheel joints with suspension
// springs and limits; the front pair steers, the rear pair drives.
build_car :: proc(t: ^Tick, index: int) {
	world := t.world.phys
	car := &t.state.cars[index]
	at := car_start(index)
	tag := CAR_TAG + u64(index) // generation 0: no prop's key
	shape_def := physics.shape_def(CAT_PROP)
	shape_def.density = 20
	car.chassis, _ = physics.create_box(world, physics.body_def(.Dynamic, at), shape_def, CAR_HALF, tag)
	upright := physics.default_parallel_joint_def()
	upright.base.local_frame_a.q = Z_TO_Y
	upright.base.local_frame_b.q = Z_TO_Y
	upright.base.collide_connected = true
	upright.hertz = CAR_UPRIGHT_HERTZ
	upright.damping_ratio = 1
	car.upright = physics.create_parallel_joint(world, physics.world_anchor(world), physics.link(car.chassis), upright)

	wheel_shape := physics.shape_def(CAT_PROP)
	wheel_shape.density = 100
	wheel_shape.base_material.friction = 3
	joint_def := physics.default_wheel_joint_def()
	joint_def.base.local_frame_a.q = X_TO_Y
	joint_def.base.local_frame_b.q = Z_TO_Y
	joint_def.enable_suspension_limit = true
	joint_def.lower_suspension_limit = -CAR_SUSPENSION_TRAVEL
	joint_def.upper_suspension_limit = CAR_SUSPENSION_TRAVEL
	joint_def.enable_suspension_spring = true
	joint_def.suspension_hertz = CAR_SUSPENSION_HERTZ
	joint_def.suspension_damping_ratio = CAR_SUSPENSION_DAMPING
	joint_def.max_spin_torque = CAR_SPIN_TORQUE
	joint_def.steering_hertz = 10
	joint_def.steering_damping_ratio = 0.7
	joint_def.max_steering_torque = CAR_STEER_TORQUE
	joint_def.enable_steering_limit = true
	joint_def.lower_steering_limit = -CAR_STEER_LIMIT
	joint_def.upper_steering_limit = CAR_STEER_LIMIT
	for &wheel, i in car.wheels {
		wheel_def := physics.body_def(.Dynamic, at + WHEEL_AT[i] + {0, 0.5, 0}, Y_TO_Z)
		wheel_def.allow_fast_rotation = true
		wheel, _ = physics.create_sphere(world, wheel_def, wheel_shape, WHEEL_RADIUS, tag)
		joint_def.base.local_frame_a.p = WHEEL_AT[i]
		front := i < 2
		joint_def.enable_steering = front
		joint_def.enable_spin_motor = !front
		car.joints[i] = physics.create_wheel_joint(world, physics.link(car.chassis), physics.link(wheel), joint_def)
	}
}

// Car `index` back at its start: its driver gets out, it is destroyed and built again.
reset_car :: proc(t: ^Tick, index: int) {
	car := &t.state.cars[index]
	if car.driver != {} do leave_car(t, car.driver)
	release_body_holders(t, {car.chassis, car.wheels[0], car.wheels[1], car.wheels[2], car.wheels[3]})
	physics.destroy_refs(t.world.phys, car)
	car^ = {}
	build_car(t, index)
}

// Cmd_Drive: a driver gets out; anyone else takes the nearest free car whose chassis is within DRIVE_RANGE of their
// camera (they let go of what they hold).
toggle_car :: proc(t: ^Tick, player: sim.Player) {
	data := sim.player_data(t, player)
	if data.car >= 0 {
		leave_car(t, player)
		return
	}
	world := t.world.phys
	nearest := -1
	best := DRIVE_RANGE * DRIVE_RANGE
	for &car, i in t.state.cars {
		if car.chassis == {} || car.driver != {} do continue
		dist := dmath.dist_sq3(physics.body_position(world, car.chassis), data.pos)
		if dist <= best do nearest, best = i, dist
	}
	if nearest < 0 do return
	release(t, player)
	t.state.cars[nearest].driver = player
	data.car = i8(nearest)
}

// `player` gets out of the car they drive (nothing when they drive none), their camera above it.
leave_car :: proc(t: ^Tick, player: sim.Player) {
	data := sim.player_data(t, player)
	if data.car < 0 do return
	car := &t.state.cars[data.car]
	car.driver = {}
	data.car = -1
	if car.chassis != {} do data.pos = physics.body_position(t.world.phys, car.chassis) + {0, 4, 0}
	data.warp += 1
}

// Each car: its driver's stick steers the front wheels (`right`, up to CAR_STEER) and drives the rear ones (`forward`,
// up to CAR_SPIN_SPEED); a car without a driver steers straight and brakes (its motors held at zero speed).
drive_cars :: proc(t: ^Tick) {
	world := t.world.phys
	for &car in t.state.cars {
		if car.chassis == {} do continue
		steer, throttle: f32
		if car.driver != {} {
			input := sim.input(t, car.driver)
			steer = f32(input.right) / 127
			throttle = f32(input.forward) / 127
		}
		for i in 0 ..< 2 do physics.wheel_joint_set_target_steering_angle(world, car.joints[i], steer * CAR_STEER)
		for i in 2 ..< 4 do physics.wheel_joint_set_spin_motor_speed(world, car.joints[i], -throttle * CAR_SPIN_SPEED)
		if steer != 0 || throttle != 0 do physics.body_set_awake(world, car.chassis, true)
	}
}
