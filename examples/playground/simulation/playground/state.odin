package playground

import "unified:dmath"
import "unified:physics"
import "unified:sim"

MAX_PROPS :: 256 // bodies the block owns at once: a scene's, the spawned, the bullets, the rain
MAX_RAGDOLLS :: 8
MAX_CARS :: PLAYERS
MAX_SENSORS :: 3

// The whole simulation state: one pointer-free block. Everything a scene builds is the block's (props, ragdolls, cars,
// sensors): a scene change destroys it all and builds the new scene's, in a fixed order.
State :: struct {
	level:    sim.Active_Level(Scene), // the scene now (enter_scene)
	players:  sim.Players(Player_Data, sim.No_Profile, Input, PLAYERS),
	props:    sim.Table(Prop, MAX_PROPS),
	ragdolls: [MAX_RAGDOLLS]physics.Ragdoll,
	cars:     [MAX_CARS]Car,
	sensors:  [MAX_SENSORS]Sensor,
	entered:  sim.Game_Time, // the tick the scene was entered (its rules count from it)
	_pad:     [4]u8,
}

// What a prop is for: how a scene's rules and the view treat it.
Role :: enum u8 {
	Scene, // built with the scene
	Spawned, // the spawn tool's (owner: who)
	Bullet, // the shoot tool's or the turret's: gone after SHOT_TICKS
	Rain, // Rain's and Conveyor's drops: the oldest goes at the cap
	Anchor, // a static or kinematic body of the scene (the turret, a sensor's post): never grabbed
}

// A body the block owns, with what a view needs to draw it: its shape and size (a box's half extents; a sphere's
// radius in x; a capsule's or cylinder's radius in x and half height in y, along its y axis).
Prop :: struct {
	body:   physics.Body_Ref,
	shape:  physics.Shape_Ref, // its one shape (the wind and the sensors read it)
	size:   [3]f32,
	owner:  sim.Player, // Spawned and Bullet: who made it
	born:   sim.Game_Time, // when it was made (bullets' life, the oldest drop)
	flash:  sim.Timer, // Sensors: lit by a hit
	kind:   Shape,
	role:   Role,
	inside: u8, // Sensors: how many sensor volumes it is in (shape_sensor_data, every tick)
	_pad:   [1]u8,
}

// A player's camera and tools (sim.Players, by member): zeroed when someone new joins.
Player_Data :: struct {
	pos:       [3]f32, // the camera
	aim:       dmath.Aim, // the last input's look
	grab:      physics.Motor_Joint_Ref, // the joint pulling what they hold (zero: nothing)
	held:      sim.Handle(Prop), // what they hold (a prop; zero: a ragdoll's bone or a car, by `held_body`)
	held_body: physics.Body_Link, // the body the grab pulls
	grab_dist: f32, // how far in front of the camera the grab point is
	cooldown:  sim.Timer, // no tool use while it runs (each tool's own length)
	car:       i8, // the car they drive (-1: none)
	warp:      u8, // moved on by every jump of the camera (a scene's start, out of a car): its view snaps
	_pad:      [2]u8,
}

// A car of the Driving scene (the Box3D sample's): a box chassis, four sphere wheels on wheel joints (the front two
// steer, the rear two drive) and a parallel joint keeping it upright.
Car :: struct {
	chassis: physics.Body_Ref,
	wheels:  [4]physics.Body_Ref, // front left, front right, rear left, rear right
	joints:  [4]physics.Wheel_Joint_Ref,
	upright: physics.Parallel_Joint_Ref,
	driver:  sim.Player, // ({}: free)
}

// A sensor volume of the Sensors scene: a static sensor box and how many bodies have entered it.
Sensor :: struct {
	body:   physics.Body_Ref,
	shape:  physics.Shape_Ref,
	visits: u32, // sensor begin events so far
	inside: u32, // bodies in it now
}
